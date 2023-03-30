
-- PMSI protocol

----------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------
const
  ProcCount: 3;          -- number processors
  ValueCount:   2;       -- number of data values.
  VC0: 0;                -- msg channel
  BufferSize: 3;   -- buffer size
  
  CoreReqBuffer_size: ProcCount; -- core request buffer
  CoreWBBuffer_size: ProcCount;  -- core write-back buffer
  PRLUT_size: ProcCount; --pending request lookup table



----------------------------------------------------------------------
-- Types
----------------------------------------------------------------------
type
  Proc: scalarset(ProcCount);   -- unordered range of processors
  Value: scalarset(ValueCount); -- arbitrary values for tracking coherence
  --addrType: scalarset(MemAddress); --------2 cache line
  
  Home: enum { HomeType };      -- need enumeration for IsMember calls
  Node: union { Home , Proc };
  

  which_fifo_type:Boolean;
  reissue: boolean;
  channelType: 0..ProcCount;

  Ackcount:(1-ProcCount)..ProcCount - 1 ;
  -- HeadPtr: 0...(ProcCount + ProcCount - 1);
  -- tailPtr: -1...(ProcCount + ProcCount - 1);

  MessageType: enum {  GetM,
                       GetS,
                       Upg,
                       PutM,
                       Data       
                    };

  Message:
    Record
      mtype: MessageType;
      src: Node;
      dest: Node;
      -- do not need a destination for verification; the destination is indicated by which array entry in the Net the message is placed
      --vc: VCType;
      val: Value;
      --addr: addrType;
      rei : reissue;
    End;

  fifo:
    Record
      buf: array [0..BufferSize-1] of Message;
      head: 0..BufferSize-1;
      tail: 0..BufferSize-1;
    end;

  HomeState:
    Record
      state: enum { 
        H_IorS, 
        H_M,
        H_IorS_D,
        H_IorS_A,
        H_M_D,
        H_IorS_req,
        H_M_req
      }; 								--transient states during recall
    val: Value; 
    PRLUT: fifo;
    channel: channelType;
    requestor: Node;
    owner: Node;
    End;

  ProcState:
    Record
      state: enum { 
            Proc_I,
            Proc_S,
            Proc_M,
            Proc_IS_D,
            Proc_IM_D,
            Proc_SM_W,
            Proc_MI_WB,
            Proc_MS_WB,
            Proc_IM_D_I,
            Proc_IS_D_I,
            Proc_IM_D_S
      };
      val: Value;
      PR:fifo;
      PWB:fifo;
      channel: channelType;
      which_fifo: which_fifo_type;
      reiss: reissue;
    End;

----------------------------------------------------------------------
-- Variables
----------------------------------------------------------------------
var
  HomeNode:  HomeState;
  Procs: array [Proc] of ProcState;
  msg_processed: boolean;
  -- ReqBuffer: array [Node] of scalarset [Proc] of Message;
  -- WBBuffer : array [Node] of scalarset [Proc] of Message;
  -- PRLUT : array [Node] of scalarset [Proc] of Message;
  -- ResBuffer: array [Node] of scalarset [Proc] of Message;
  LastWrite: Value; -- Used to confirm that writes are not lost; this variable would not exist in real hardware

  current_channel: channelType;
  temp_msg: Message;
   --true for PR, false for PWB

----------------------------------------------------------------------
-- Procedures
----------------------------------------------------------------------
Procedure Enqueue(f:fifo; msg: Message);
Begin
  --assert (f.head != (f.tail + 1) % BufferSize) "a fifo overflowed!"; -- check if the queue is full
  f.buf[f.tail] := msg;
  f.tail := (f.tail + 1) % BufferSize;
End;

Function Dequeue(f:fifo): Message;
Begin
  --assert f.head != f.tail; -- check if the queue is not empty
  if (f.head = f.tail) then
    return UNDEFINED;
  endif;
  
  var msg := f.buf[f.head];
  f.head := (f.head + 1) % BufferSize;
  return msg;
End;

Procedure BufferReissue(f:fifo);
Begin
  f.tail := (f.tail + BufferSize - 1) % BufferSize;
End;


Function Peek(f:fifo): Message;
Begin
  --assert f.head != f.tail; -- check if the queue is not empty
  if (f.head = f.tail) then
    return UNDEFINED;
  endif;
  var msg := f.buf[f.head];
  return msg;
End;


Procedure ToBuffer(
            f:fifo;
            mtype:MessageType;
            dest: Node;
            src:Node;
            val:Value
            
          );
var msg:Message; 
Begin
  -- data msg counts as WB, everything else counts as pending request
  --Assert (MultiSetCount(i:Net[dst], true) < NetMax) "Too many messages";
  msg.mtype := mtype;
  msg.dest := dest;
  msg.src   := src;
  msg.val   := val;
  Enqueue(f, msg);
End;

Procedure ErrorUnhandledMsg(msg:Message; n:Node);
Begin
  error "Unhandled message type!";
End;

Procedure ErrorUnhandledState();
Begin
  error "Unhandled state!";
End;

Procedure HomeSend(
                  mtype:MessageType;
                  dest: Node;
                  val:Value
                );
var msg:Message; 
begin
  msg.mtype := mtype;
  msg.dest := dest;
  msg.src   := HomeType;
  msg.val   := val;
  for i:Proc do
    ProcReceive(msg, i);
  endfor;
end;

-- These aren't needed for Valid/Invalid protocol, but this is a good way of writing these functions




Procedure HomeReceive(msg:Message);
Begin
-- Debug output may be helpful:
--  put "Receiving "; put msg.mtype; put " on VC"; put msg.vc; 
--  put " at home -- "; put HomeNode.state;

  -- The line below is not needed in Valid/Invalid protocol.  However, the 
  -- compiler barfs if we put this inside a switch, so it is useful to
  -- pre-calculate the sharer count here
  
   
  -- default to 'processing' message.  set to false otherwise
  msg_processed := true;

  switch HomeNode.state
  case H_IorS:
    switch msg.mtype
      case GetS:
        HomeSend(Data, msg.src, HomeNode.val);

      case GetM:
        HomeNode.state := H_M;
        HomeSend(Data, msg.src, HomeNode.val);
        HomeNode.owner := msg.src;

      case Upg:
        HomeNode.state := H_M;
        HomeNode.owner := msg.src;

      case PutM:
        if (msg.src = HomeNode.owner) then
          ErrorUnhandledMsg(msg, HomeType);
        else
          --do nothing
        endif;
      
      case Data:
        if (IsUndefined(msg.requestor)) then 
          ErrorUnhandledMsg(msg, HomeType);
        else 
          ErrorUnhandledMsg(msg, HomeType);
        endif;

      else
        ErrorUnhandledMsg(msg, HomeType);
    endswitch;
    

    case H_M:
      switch msg.mtype
        case GetS:
          undefine HomeNode.owner;
          requestor := msg.src;
          HomeNode.state := H_IorS_D;      
        case GetM:
          HomeNode.owner := msg.src;
          requestor := msg.src;
          HomeNode.state :=H_M_D;
          
        case Upg :
          ErrorUnhandledMsg(msg, HomeType);

        case PutM:
          if (msg.src = HomeNode.owner) then
            undefine HomeNode.owner;
            HomeNode.state := H_IorS_D;
          endif;
        
        case Data:
          if(isundefined(requestor)) then
            HomeNode.state := H_IorS_A;
          else
             ErrorUnhandledMsg(msg, HomeType);
          endif;
          
        else
          ErrorUnhandledMsg(msg, HomeType);
    endswitch;
    

  case H_IorS_D:
    switch msg.mtype
      case GetS:
        msg_processed = false;

      case GetM:
        msg_processed = false;
        
      case Upg:
        ErrorUnhandledMsg(msg, HomeType);

      case PutM:
        if (msg.src = HomeNode.owner) then
          msg_processed = false;
        else
          --do nothing
        endif;
      
      case Data:
        if (IsUndefined(msg.requestor)) then 
          HomeNode.state := H_IorS;
          HomeNode.val := msg.val;
        else 
          HomeNode.state := H_IorS_req;
          HomeNode.val := msg.val;
        endif;

      else
        ErrorUnhandledMsg(msg, HomeType);
    endswitch;
    

    case H_IorS_A:
      switch msg.mtype
        case GetS:
          HomeNode.state := H_IorS;
          HomeSend(Data, msg.requestor, HomeNode.val);
        case GetM:
          HomeNode.state := H_M;
          HomeNode.owner := msg.src;
          HomeSend(Data, msg.requestor, HomeNode.val);
        case Upg:
          ErrorUnhandledMsg(msg, HomeType);
        case PutM:
          if (msg.src = HomeNode.owner) then
            HomeNode.owner := UNDEFINED;
            HomeNode.state := H_IorS;
          else
            ErrorUnhandledMsg(msg, HomeType);
          endif;
        case Data:
          if (msg.requestor = UNDEFINED) then 
            ErrorUnhandledMsg(msg, HomeType);
          else 
            ErrorUnhandledMsg(msg, HomeType);
          endif;
        else
          ErrorUnhandledMsg(msg, HomeType);
    endswitch;
    

  case H_M_D:
    switch msg.mtype
      case GetS:
        msg_processed := false;

      case GetM:
        msg_processed := false;

      case Upg:
        ErrorUnhandledMsg(msg, HomeType);

      case PutM:
        if (msg.src = HomeNode.owner) then
          ErrorUnhandledMsg(msg, HomeType);
        else
          --do nothing
        endif;
      
      case Data:
        if (msg.requestor = UNDEFINED) then 
          HomeNode.state := H_M;
        else 
          HomeNode.state := H_M_req;
        endif;

      else
        ErrorUnhandledMsg(msg, HomeType);
    endswitch;
    

  case H_IorS_req:
    switch msg.mtype
      case GetS:
        msg_processed := false;

      case GetM:
        msg_processed := false;

      case Upg:
        ErrorUnhandledMsg(msg, HomeType);

      case PutM:
        if (msg.src = HomeNode.owner) then
          ErrorUnhandledMsg(msg, HomeType);
        else
          --do nothing
        endif;
      
      case Data:
        if (msg.requestor = UNDEFINED) then 
          ErrorUnhandledMsg(msg, HomeType);
        else 
          ErrorUnhandledMsg(msg, HomeType);
        endif;

      else
        ErrorUnhandledMsg(msg, HomeType);

    endswitch;
    

    case H_M_req:
      switch msg.mtype
        case GetS:
          msg_processed := false;

        case GetM:
          msg_processed := false;

        case Upg:
          ErrorUnhandledMsg(msg, HomeType);

        case PutM:
          if (msg.src = HomeNode.owner) then
            ErrorUnhandledMsg(msg, HomeType);
          else
            --do nothing
          endif;
        
        case Data:
            ErrorUnhandledMsg(msg, HomeType);

        else
          ErrorUnhandledMsg(msg, HomeType);

    endswitch;

  endswitch;
  
End;


Procedure ProcReceive(msg:Message; p:Proc);
Begin
--  put "Receiving "; put msg.mtype; put " on VC"; put msg.vc; 
--  put " at proc "; put p; put "\n";

  -- default to 'processing' message.  set to false otherwise
  msg_processed := true;

  alias ps:Procs[p].state do
  alias pv:Procs[p].val do
  alias pwbuffer: Procs[p].PWB do
  alias prebuffer: Procs[p].PR do
  alias preissue: Procs[p].reiss do

  switch ps
    case Proc_I:
        ErrorUnhandledMsg(msg, p);

    case Proc_S:     
      if (msg.src = p | (msg.src = HomeType & msg.dest = p)) then --own
        switch msg.mtype
          case Upg:
            ErrorUnhandledMsg(msg, p);
          case PutM:
            ErrorUnhandledMsg(msg, p);
          case Data:

          else
            ErrorUnhandledMsg(msg, p);

        endswitch;
      else --other
        switch msg.mtype
          case GetM:
            ps := Proc_I;
          case Upg:
            ps := Proc_I;
          case Data:

          else
            ErrorUnhandledMsg(msg, p);
        endswitch;
      endif;

    case Proc_M:     
      if (msg.src = p | (msg.src = HomeType & msg.dest = p)) then --own
        switch msg.mtype
          case Data:
            ErrorUnhandledMsg(msg, p);
          case Upg:
            ErrorUnhandledMsg(msg, p);
          case PutM:
            ErrorUnhandledMsg(msg, p);
          else
            ErrorUnhandledMsg(msg, p);
        endswitch;
      else --other
        switch msg.mtype
          case GetS:
            ps := Proc_MS_WB;
            ToBuffer(prebuffer, PutM, HomeType, p, pv);
          case GetM:
            ps := Proc_MI_WB;
            ToBuffer(prebuffer, PutM, HomeType, p, pv);
          case Upg:
            ErrorUnhandledMsg(msg, p);
          case PutM:
            ErrorUnhandledMsg(msg, p);
          case Data:

          else
            ErrorUnhandledMsg(msg, p);
        endswitch;
      endif;

    case Proc_IS_D:
      if (msg.src = p | msg.src = HomeType) then --own
        switch msg.mtype
          case Data:
            ps := Proc_S;
            pv := msg.val;
          case Upg:
            ErrorUnhandledMsg(msg, p);
          case PutM:
            ErrorUnhandledMsg(msg, p);
          case Data:

          else
            ErrorUnhandledMsg(msg, p);
        endswitch;
      else --other
        switch msg.mtype
          case GetS:
            
          case GetM:
            ps := Proc_IS_D_I;
          case Upg:
            ps := Proc_IS_D_I;
          case PutM:

          case Data:

          else
            ErrorUnhandledMsg(msg, p);
        endswitch;
      endif;

    case Proc_IM_D:
      if (msg.src = p | msg.src = HomeType) then --own
        switch msg.mtype
          case Data:
            ps := Proc_M;
            LastWrite := msg.val; --write
          case Upg:
            ErrorUnhandledMsg(msg, p);
          case PutM:
            ErrorUnhandledMsg(msg, p);
          case Data:

          else
            ErrorUnhandledMsg(msg, p);
        endswitch;
      else --other
        switch msg.mtype
          case GetS:
            ErrorUnhandledMsg(msg, p);
          case GetM:
            ErrorUnhandledMsg(msg, p);
          case Upg:
            ErrorUnhandledMsg(msg, p);
          case PutM:
            ErrorUnhandledMsg(msg, p);
          case Data:

          else
            ErrorUnhandledMsg(msg, p);
        endswitch;
      endif;

    case Proc_SM_W:     
      if (msg.src = p | (msg.src = HomeType & msg.dest = p)) then --own
        switch msg.mtype
          case Data:

          case Upg:
            ps := Proc_M;
            pv := msg.val;
            LastWrite := msg.val; --write
          case PutM:
            ErrorUnhandledMsg(msg, p);

          else
            ErrorUnhandledMsg(msg, p);
        endswitch;
      else --other
        switch msg.mtype
          case GetS:
            
          case GetM:
            ps := Proc_I;
            --reissue: not last write
            preissue := true;
            BufferReissue(prebuffer);
          case Upg:
            ps := Proc_I;
            preissue := true;
            BufferReissue(prebuffer);
            --reissue: not last write
          case PutM:
            ErrorUnhandledMsg(msg, p);
          case Data:

          else
            ErrorUnhandledMsg(msg, p);
        endswitch;
      endif;

    case Proc_MI_WB:     
      if (msg.src = p | (msg.src = HomeType & msg.dest = p)) then --own
        switch msg.mtype
          case Data:
            
          case Upg:
            ErrorUnhandledMsg(msg, p);
          case PutM:
            ps := I;
            ToBuffer(pwbuffer, Data, HomeType, p, pv);

          else
            ErrorUnhandledMsg(msg, p);
        endswitch;
      else --other
        switch msg.mtype
          case GetS:
            
          case GetM:
            
          case Upg:
            ErrorUnhandledMsg(msg, p);
          case PutM:
            ErrorUnhandledMsg(msg, p);
          case Data:

          else
            ErrorUnhandledMsg(msg, p);
        endswitch;
      endif;

      case Proc_MS_WB:
      if (msg.src = p | (msg.src = HomeType & msg.dest = p)) then --own
        switch msg.mtype
          case Data:

          case Upg:
            ErrorUnhandledMsg(msg, p);
          case PutM:
            ps := S;
            ToBuffer(pwbuffer, Data, HomeType, p, pv);
          else
            ErrorUnhandledMsg(msg, p);
        endswitch;
      else --other
        switch msg.mtype
          case GetS:
            
          case GetM:
            ps := Proc_MI_WB;
          case Upg:
            ErrorUnhandledMsg(msg, p);
          case PutM:
            ErrorUnhandledMsg(msg, p);
          case Data:

          else
            ErrorUnhandledMsg(msg, p);
        endswitch;
      endif;

    case Proc_IM_D_I:
      if (msg.src = p | (msg.src = HomeType & msg.dest = p)) then --own
        switch msg.mtype
          case Data:
            ps := Proc_MI_WB;
            ToBuffer(prebuffer, PutM, HomeType, p, UNDEFINED);
            LastWrite := msg.val; --write
          case Upg:
            ErrorUnhandledMsg(msg, p);
          case PutM:
            ErrorUnhandledMsg(msg, p);
          case Data:

          else
            ErrorUnhandledMsg(msg, p);
        endswitch;
      else --other
        switch msg.mtype
          case GetS:
            
          case GetM:
            
          case Upg:
            ErrorUnhandledMsg(msg, p);
          case PutM:

          case Data:

          else
            ErrorUnhandledMsg(msg, p);
        endswitch;
      endif;

    case Proc_IS_D_I:
      if (msg.src = p | (msg.src = HomeType & msg.dest = p)) then --own
        switch msg.mtype
          case Data:
            ps := I;
            pv := msg.val;
            LastWrite := msg.val; --write
          case Upg:
            ErrorUnhandledMsg(msg, p);
          case PutM:
            ErrorUnhandledMsg(msg, p);
          else
            ErrorUnhandledMsg(msg, p);
        endswitch;
      else --other
        switch msg.mtype
          case GetS:
            
          case GetM:
            
          case Upg:
            
          case PutM:

          case Data:

          else
            ErrorUnhandledMsg(msg, p);
        endswitch;
      endif;

    case Proc_IM_D_S:
      if (msg.src = p | (msg.src = HomeType & msg.dest = p)) then --own
        switch msg.mtype
          case Data:
            ps := Proc_MS_WB;
            ToBuffer(prebuffer, PutM, HomeType, p, UNDEFINED);
          case Upg:
            ErrorUnhandledMsg(msg, p);
          case PutM:
            ErrorUnhandledMsg(msg, p);
          else
            ErrorUnhandledMsg(msg, p);
        endswitch;
      else --other
        switch msg.mtype
          case GetS:
            
          case GetM:
            ps := Proc_IM_D_I;
          case Upg:
            ErrorUnhandledMsg(msg, p);
          case PutM:
          
          case Data:

          else
            ErrorUnhandledMsg(msg, p);
        endswitch;
      endif;
  else
    ErrorUnhandledState();

  endswitch;
  
  endalias;
  endalias;
  endalias;
  endalias;
  endalias;
End;

----------------------------------------------------------------------
-- Rules
----------------------------------------------------------------------

-- core events

ruleset n:Proc Do
  alias p:Procs[n] Do

	ruleset v:Value Do
  	rule "@ P store"
   	 (p.state = Proc_I | p.state = Proc_S | p.state = Proc_M | p.state = Proc_MI_WB | p.state = Proc_MS_WB)
    	==>
      switch p.state
        case Proc_I:
          ToBuffer(p.PR, GetM, HomeType, n, UNDEFINED);
          p.state := Proc_IM_D;
           pv := v;

          
        case Proc_S:
          ToBuffer(p.PR, Upg, HomeType, n, v); --forward value to itself
          p.state := Proc_SM_W;

        case Proc_M:
          pv := v;
          LastWrite := v;

        case Proc_MI_WB:
          pv := v;
          LastWrite := v;

        case Proc_MS_WB:
          pv := v;
          LastWrite := v;

        else
      
  	endrule;
	endruleset;

  ruleset v:Value do
      rule "reissue"
   (p.state = Proc_I & p.reiss) 
  ==>
      ToBuffer(p.PR, GetM, HomeType, n, UNDEFINED);
      p.state := Proc_IM_D;
      p.reiss =false;
      pv := v;

  	endrule;
	endruleset;

  
  rule "@ P load"
    (p.state = Proc_I | p.state = Proc_S | p.state = Proc_MI_WB | p.state = Proc_MS_WB | p.state = Proc_M )
  ==>
    switch p.state
      case Proc_I:
        ToBuffer(p.PR, GetS, HomeType, n, UNDEFINED);
        p.state := Proc_IS_D;

        case Proc_S:

        case Proc_MI_WB:

        case Proc_MS_WB:   

        case Proc_M:     
      else

    endswitch;
  endrule;

  rule "@ P evict"
    ( p.state = Proc_S | p.state = Proc_M | p.state = Proc_MS_WB )
  ==>
    switch p.state
      case Proc_S:
        p.state := Proc_I;

      case Proc_M:
        ToBuffer(p.PR, PutM, HomeType, n, p.val);      
        p.state := Proc_MI_WB;

      case Proc_MS_WB:
        p.state := Proc_MI_WB;
      
      else

    endswitch;
  endrule;

  endalias;
endruleset;
----------- new bus msg passing rules ----------------------
-- procs can only send one message per window

ruleset n:Proc Do
  alias p:Procs[n] Do
    rule "proc send to bus"
      (current_channel = p.channel)
    ==>
      if (p.which_fifo) then
        --PR dequeue
        temp_msg := Dequeue(p.PR);
        if(!isundefined(temp_msg)) then
          for i:Proc do --all proc receive message
            ProcReceive(temp_msg, i);
          endfor;
          Enqueue(HomeNode.PRLUT, temp_msg); --mem LUT enqueue msg
        endif;
      else 
        --PWB dequeue (WB are data message)
        temp_msg := Dequeue(p.PWB);
        if(!isundefined(temp_msg)) then
          ProcReceive(temp_msg, i);
          --Enqueue(HomeNode.PRLUT, temp_msg);  --mem LUT enqueue msg
        endif;
      endif;

      p.which_fifo := !p.which_fifo; --proc fifo arbitor
      current_channel := (current_channel+1) % (ProcCount+1); -- all nodes arbitor (proc and home rotate)
  endalias;
endruleset;

--mem consume LUT (can it consume multiple?)
rule "mem consume LUT"
    (current_channel = 0)
  ==>
    temp_msg := Peek(HomeNode.PRLUT);
    if(HomeNode.state = H_IorS_req) then
      Homesend(Data,HomeNode.requestor,HomeNode.val);
      undefine HomeNode.requestor
      HomeNode.state := H_IorS;
    elsif(HomeNode.state = H_M_req) then
      Homesend(Data,HomeNode.requestor,HomeNode.val);
      undefine HomeNode.requestor
      HomeNode.state := H_M;   
    else 
      if(!isundefined(temp_msg)) then
        HomeReceive(temp_msg);
        if (msg_processed) then
          Dequeue(HomeNode.PRLUT);
      endif;
    endif;
    endif;
    current_channel := (current_channel+1) % (ProcCount+1);
endrule

----------------------------------------------------------------------
-- Startstate
----------------------------------------------------------------------
startstate

	For v:Value do
    -- home node initialization
    HomeNode.state := H_IorS;
    undefine HomeNode.owner;
    undefine HomeNode.requestor;
    HomeNode.val := v;
	endfor;
  HomeNode.channel := 0;
  HomeNode.PRLUT.head := 0;
  HomeNode.PRLUT.tail := 0;

	LastWrite := HomeNode.val;
  
  -- processor initialization
  for i:Proc do
    Procs[i].state := Proc_I;
    undefine Procs[i].val;
    Procs[i].channel := i+1;
    Procs[i].which_fifo := true; --start with PR
    Procs[i].PR.head := 0;
    Procs[i].PR.tail := 0;
    Procs[i].PWB.head := 0;
    Procs[i].PWB.tail := 0;
    Procs[i].reissue := false;
  endfor;

endstartstate;

----------------------------------------------------------------------
-- Invariants
----------------------------------------------------------------------
/*

invariant "Invalid implies empty owner"
  HomeNode.state = H_Invalid | HomeNode.state = H_Shared
    ->
      IsUndefined(HomeNode.owner);

-- invariant "value in memory matches value of last write, when invalid"
--      HomeNode.state = H_Invalid 
--     ->
-- 			HomeNode.val = LastWrite;

invariant "values in valid state match last write"
  Forall n : Proc Do	
     Procs[n].state = P_Modified
    ->
			Procs[n].val = LastWrite --LastWrite is updated whenever a new value is created 
	end;
	
invariant "value is undefined while invalid"
  Forall n : Proc Do	
     Procs[n].state = P_Invalid
    ->
			IsUndefined(Procs[n].val)
	end;
	

-- Here are some invariants that are helpful for validating shared state.

invariant "modified implies empty sharers list"
  HomeNode.state = H_Modified
    ->
      MultiSetCount(i:HomeNode.sharers, true) = 0;

invariant "Invalid implies empty sharer list"
  HomeNode.state = H_Invalid
    ->
      MultiSetCount(i:HomeNode.sharers, true) = 0;

invariant "values in memory matches value of last write, when shared or invalid"
  Forall n : Proc Do	
     HomeNode.state = H_Shared | HomeNode.state = H_Invalid
    ->
			HomeNode.val = LastWrite
	end;

invariant "values in shared state match memory"
  Forall n : Proc Do	
     HomeNode.state = H_Shared & Procs[n].state = P_Shared
    ->
			HomeNode.val = Procs[n].val
	end;

invariant "home in M state implies owner exists"
  HomeNode.state = H_Modified
    ->
      HomeNode.owner != HomeType;

invariant "home in S state implies non-empty sharer list"
  HomeNode.state = H_Shared
    ->
      MultiSetCount(i: HomeNode.sharers, true) != 0;

  invariant "processor in Modified state,  no Sharers"
  Forall n : Proc Do
    Forall m : Proc Do
      ((Procs[n].state = P_Modified) & (n != m)) 
        -> 
          (Procs[m].state != P_Shared & Procs[m].state != P_Modified)
    end
  end;
*/



-- const
--   MAX_QUEUE_SIZE: 10;
--   NUM_CORES: 2;

-- type
--   QueueIndex: 0..MAX_QUEUE_SIZE-1;
--   Core: record
--     queue: array [QueueIndex] of int;
--     front: QueueIndex;
--     rear: QueueIndex;
--   end;

-- var
--   cores: array [0..NUM_CORES-1] of Core;

-- function QueueIsEmpty(core_id: 0..NUM_CORES-1): boolean;
-- begin
--   return cores[core_id].front = cores[core_id].rear;
-- endfunction;

-- function QueueIsFull(core_id: 0..NUM_CORES-1): boolean;
-- begin
--   return (cores[core_id].rear+1) mod MAX_QUEUE_SIZE = cores[core_id].front;
-- endfunction;

-- procedure Enqueue(core_id: 0..NUM_CORES-1; item: int);
-- begin
--   if not QueueIsFull(core_id) then
--     cores[core_id].queue[cores[core_id].rear] := item;
--     cores[core_id].rear := (cores[core_id].rear + 1) mod MAX_QUEUE_SIZE;
--   endif;
-- endprocedure;

-- function Dequeue(core_id: 0..NUM_CORES-1): int;
-- var
--   item: int;
-- begin
--   if not QueueIsEmpty(core_id) then
--     item := cores[core_id].queue[cores[core_id].front];
--     cores[core_id].front := (cores[core_id].front + 1) mod MAX_QUEUE_SIZE;
--     return item;
--   endif;
-- endfunction;
